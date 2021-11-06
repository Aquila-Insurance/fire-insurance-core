const shp = require('shpjs');
const fs = require('fs');

let shapeUrl = "https://pub.data.gov.bc.ca/datasets/cdfc2d7b-c046-4bf0-90ac-4897232619e1/prot_current_fire_polys.zip";

shp(shapeUrl).then(function(geojson){
let json = JSON.stringify(geojson);
fs.writeFile('./test/prot_current_fire_polys.geojson', json, 'utf8', function(err) {
    if (err) {
        console.log(err);
    } else {
        console.log('Geojson file written successfully')
    }
});
}).catch( (reason) => {
console.log('Handle rejected promise ('+reason+') here.');
});
